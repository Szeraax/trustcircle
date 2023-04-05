CREATE TABLE [dbo].[Player] (
    [Id]     INT           NOT NULL IDENTITY PRIMARY KEY  CLUSTERED ([Id] ASC),
    [Game]   INT           NULL,
    [UserId] VARCHAR (50)  NULL,
    [Username] VARCHAR (150)  NULL,
    [Label]   VARCHAR (50)  NULL,
    [Count]   INT  NULL,
    [Members]   VARCHAR(MAX)  NULL,
    [Key]    VARCHAR (300) NULL,
    [Status] VARCHAR (50)  CONSTRAINT [DEFAULT_Player_Status] DEFAULT 'Intact' NULL,
    CONSTRAINT [FK_Player_Game] FOREIGN KEY ([Game]) REFERENCES [dbo].[Game] ([Id]) ON DELETE CASCADE ON UPDATE CASCADE
);
