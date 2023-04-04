CREATE TABLE [dbo].[Action] (
    [Id]           BIGINT       NOT NULL PRIMARY KEY CLUSTERED ([Id] ASC),
    [Player]       INT          NULL,
    [TargetPlayer] INT          NULL,
    [Type]         VARCHAR (50) NULL,
    CONSTRAINT [FK_Action_Player] FOREIGN KEY ([Player]) REFERENCES [dbo].[Player] ([Id]) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT [FK_Action_Player2] FOREIGN KEY ([TargetPlayer]) REFERENCES [dbo].[Player] ([Id])
);
